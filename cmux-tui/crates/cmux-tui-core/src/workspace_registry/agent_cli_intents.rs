//! Non-secret UI update intent identity, durably recorded before dispatch.
//! This ledger grants no execution authority and never contains argv or credentials.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Actor, WorkspaceRegistry};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct AgentCLIIntent {
    pub key: String,
    pub root_key: String,
    pub machine: String,
    pub session: String,
    pub cli: String,
    pub profiles: Vec<String>,
}

impl WorkspaceRegistry {
    pub(crate) fn record_agent_cli_intents(
        &mut self,
        _actor: &Actor,
        _intents: &[AgentCLIIntent],
    ) -> anyhow::Result<(Vec<Value>, bool)> {
        anyhow::bail!("agent update intent ledger is unavailable")
    }

    pub(crate) fn list_agent_cli_intents(&self, _actor: &Actor) -> anyhow::Result<Vec<Value>> {
        anyhow::bail!("agent update intent ledger is unavailable")
    }

    pub(crate) fn attach_agent_cli_intent_receipt(
        &mut self,
        _actor: &Actor,
        _key: &str,
        _receipt: &Value,
    ) -> anyhow::Result<(Value, bool)> {
        anyhow::bail!("agent update intent ledger is unavailable")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn intent() -> AgentCLIIntent {
        AgentCLIIntent {
            key: "original-child".into(),
            root_key: "original-root".into(),
            machine: format!("machine_{}", "1".repeat(32)),
            session: format!("session_{}", "2".repeat(32)),
            cli: "claude".into(),
            profiles: vec!["work-profile".into()],
        }
    }

    fn actor() -> Actor {
        Actor::Frontend { install_id: "original-install".into() }
    }

    fn root() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("cmux-agent-intents-{}", super::super::new_uuid_v4()))
    }

    fn receipt() -> Value {
        json!({"machine":intent().machine,"session":intent().session,"cli":"claude",
            "revision":"18446744073709551615","replayed":false,"path":{
                "kind":"terminal","workspace_id":format!("ws_{}", "a".repeat(32)),
                "screen_id":format!("screen_{}", "a".repeat(32)),"pane_id":format!("pane_{}", "a".repeat(32)),
                "tab_id":format!("tab_{}", "a".repeat(32)),"terminal_id":format!("term_{}", "a".repeat(32))}})
    }

    #[test]
    fn cmux_next_agent_cli_intent_keeps_original_identity_and_receipt_after_reopen() {
        let root = root();
        {
            let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
            let (rows, changed) = registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
            assert!(changed);
            assert_eq!(rows[0]["key"], "original-child");
            assert_eq!(rows[0]["root_key"], "original-root");
            assert_eq!(rows[0]["receipt"], Value::Null);
            let (row, changed) = registry
                .attach_agent_cli_intent_receipt(&actor(), "original-child", &receipt())
                .unwrap();
            assert!(changed);
            assert_eq!(row["receipt"]["revision"], "18446744073709551615");
        }
        let registry = WorkspaceRegistry::open(&root, "intents").unwrap();
        let rows = registry.list_agent_cli_intents(&actor()).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["machine"], intent().machine);
        assert_eq!(rows[0]["receipt"]["path"]["terminal_id"], receipt()["path"]["terminal_id"]);
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_agent_cli_intent_batch_is_atomic_and_keys_cannot_retarget() {
        let root = root();
        let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
        let mut bad = intent();
        bad.key = "second".into();
        bad.session = "current".into();
        assert!(registry.record_agent_cli_intents(&actor(), &[intent(), bad]).is_err());
        assert!(registry.list_agent_cli_intents(&actor()).unwrap().is_empty());
        registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
        assert!(!registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap().1);
        for field in ["machine", "session", "cli", "root_key", "profiles"] {
            let mut changed = serde_json::to_value(intent()).unwrap();
            changed[field] =
                if field == "profiles" { json!(["other-profile"]) } else { json!("different") };
            let changed: AgentCLIIntent = serde_json::from_value(changed).unwrap();
            assert!(registry.record_agent_cli_intents(&actor(), &[changed]).is_err());
        }
        assert_eq!(registry.list_agent_cli_intents(&actor()).unwrap().len(), 1);
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_agent_cli_intent_receipts_require_the_original_owner_cli_and_public_path() {
        let root = root();
        let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
        registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
        for field in ["machine", "session", "cli", "argv"] {
            let mut foreign = receipt();
            foreign[field] = json!("foreign");
            assert!(
                registry
                    .attach_agent_cli_intent_receipt(&actor(), "original-child", &foreign)
                    .is_err()
            );
        }
        let mut malformed = receipt();
        malformed["path"]["terminal_id"] = json!("private-host-id");
        assert!(
            registry
                .attach_agent_cli_intent_receipt(&actor(), "original-child", &malformed)
                .is_err()
        );
        registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &receipt()).unwrap();
        let mut replay = receipt();
        replay["replayed"] = json!(true);
        assert!(
            !registry
                .attach_agent_cli_intent_receipt(&actor(), "original-child", &replay)
                .unwrap()
                .1
        );
        replay["path"]["terminal_id"] = json!(format!("term_{}", "b".repeat(32)));
        assert!(
            registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &replay).is_err()
        );
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_agent_cli_intent_store_is_principal_scoped_and_not_execution_authority() {
        let root = root();
        let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
        registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
        let other = Actor::Frontend { install_id: "other-install".into() };
        assert!(registry.list_agent_cli_intents(&other).unwrap().is_empty());
        assert!(
            registry.attach_agent_cli_intent_receipt(&other, "original-child", &receipt()).is_err()
        );
        for denied in [Actor::Daemon, Actor::local_user(), Actor::App { id: "claim".into() }] {
            assert!(registry.record_agent_cli_intents(&denied, &[intent()]).is_err());
            assert!(registry.list_agent_cli_intents(&denied).is_err());
        }
        let mut arbitrary = serde_json::to_value(intent()).unwrap();
        arbitrary["argv"] = json!(["anything"]);
        assert!(serde_json::from_value::<AgentCLIIntent>(arbitrary).is_err());
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }
}
